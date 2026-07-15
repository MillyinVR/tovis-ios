#if DEBUG
// A DEBUG-only read-out of the last card scan — the tight-loop tool for tuning a
// calibration target's geometry against a REAL chart (notably the ColorChecker
// Classic, whose ccBorder/ccGap/ccInset/aspect/detection constants are first-pass
// estimates). Instead of only "Card locked" / "couldn't read", this shows WHY a
// read passed or failed: the gray-ramp gate + ramp lumas, the solved matrix
// (shown even when the plausibility gate rejects it) with its diagonal /
// off-diagonal / determinant, the exposure anchor, and per-patch measured-vs-
// reference sRGB. When the sampled grid is off the patches, the measured swatches
// won't match the reference and the ramp won't be monotone — visible at a glance.
import SwiftUI
import TovisKit

struct CalibrationDiagnosticsView: View {
    let diagnostics: CalibrationDiagnostics
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    verdict
                    grayRampSection
                    matrixSection
                    exposureSection
                    patchesSection
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary)
            .navigationTitle("Scan diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Verdict

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: diagnostics.wouldCalibrate ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(diagnostics.wouldCalibrate ? BrandColor.emerald : BrandColor.ember)
                Text(diagnostics.wouldCalibrate ? "Would calibrate" : "Would NOT calibrate")
                    .font(BrandFont.display(17))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            Text("Ref: \(diagnostics.targetId)")
                .font(BrandFont.mono(12)).foregroundStyle(BrandColor.textMuted)
        }
    }

    // MARK: - Gray ramp

    private var grayRampSection: some View {
        section("Gray-ramp gate", pass: diagnostics.grayRampPasses) {
            Text(diagnostics.grayRampPasses
                 ? "Monotone light→dark, near-neutral — the read gate accepts."
                 : "Not monotone / not neutral — the read gate rejects. If the numbers below look close, the grid is slightly off the patches.")
                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            if diagnostics.grayRampLumas.isEmpty {
                mono("no ramp (swatch count mismatch)")
            } else {
                mono("lumas  " + diagnostics.grayRampLumas.map { fmt($0, 3) }.joined(separator: "  "))
            }
        }
    }

    // MARK: - Matrix

    private var matrixSection: some View {
        section("3×3 solve", pass: diagnostics.matrix != nil && diagnostics.isPlausible) {
            if let diagonal = diagnostics.matrixDiagonal {
                mono("diag     " + diagonal.map { fmt($0, 3) }.joined(separator: "  "))
                if let off = diagnostics.matrixOffDiagonal {
                    mono("off-diag " + off.map { fmt($0, 3) }.joined(separator: " "))
                }
                mono("|off|max " + fmt(diagnostics.maxOffDiagonal ?? 0, 3) + "   (gate ≤ 0.6)")
                mono("det      " + fmt(diagnostics.determinant ?? 0, 4) + "   (gate > 0.05)")
                mono("plausible " + (diagnostics.isPlausible ? "yes" : "NO"))
            } else {
                Text("Solve failed — couldn't invert the swatch matrix (grid not on the patches, or a degenerate read).")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.ember)
            }
        }
    }

    // MARK: - Exposure + neutral

    private var exposureSection: some View {
        section("Exposure anchor", pass: diagnostics.exposureBiasEV != nil) {
            if let ev = diagnostics.exposureBiasEV {
                mono("EV bias  " + fmt(ev, 3))
            } else {
                mono("EV bias  unreadable (neutral luma ~0)")
            }
            HStack(spacing: 10) {
                swatchPair(measured: diagnostics.neutralMeasuredSRGB,
                           reference: diagnostics.neutralReferenceSRGB)
                VStack(alignment: .leading, spacing: 2) {
                    mono("neutral meas " + rgb255(diagnostics.neutralMeasuredSRGB))
                    mono("neutral ref  " + rgb255(diagnostics.neutralReferenceSRGB))
                }
            }
        }
    }

    // MARK: - Per-patch

    private var patchesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Patches (measured vs reference)")
                .font(BrandFont.display(14)).foregroundStyle(BrandColor.textPrimary)
            if diagnostics.patches.isEmpty {
                mono("no patches (swatch count mismatch)")
            } else {
                VStack(spacing: 4) {
                    ForEach(diagnostics.patches, id: \.index) { patch in
                        HStack(spacing: 8) {
                            Text(String(format: "%2d", patch.index + 1))
                                .font(BrandFont.mono(11)).foregroundStyle(BrandColor.textMuted)
                            swatchPair(measured: patch.measuredSRGB, reference: patch.referenceSRGB)
                            mono(rgb255(patch.measuredSRGB))
                            Text("vs").font(BrandFont.mono(10)).foregroundStyle(BrandColor.textMuted)
                            mono(rgb255(patch.referenceSRGB))
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Building blocks

    private func section(_ title: String, pass: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(pass ? BrandColor.emerald : BrandColor.ember).frame(width: 8, height: 8)
                Text(title).font(BrandFont.display(14)).foregroundStyle(BrandColor.textPrimary)
            }
            content()
        }
    }

    /// Measured sample over its reference — a side-by-side split swatch so a
    /// grid that's off the patches jumps out (the two halves diverge).
    private func swatchPair(measured: RGB, reference: RGB) -> some View {
        HStack(spacing: 0) {
            color(measured)
            color(reference)
        }
        .frame(width: 34, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.15)))
    }

    private func color(_ c: RGB) -> some View {
        Color(red: c.r, green: c.g, blue: c.b)
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(BrandFont.mono(12)).foregroundStyle(BrandColor.textSecondary)
    }

    private func fmt(_ x: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", x)
    }

    /// An sRGB triple (0…1) as "r,g,b" in 0…255 — how a designer reads a patch.
    private func rgb255(_ c: RGB) -> String {
        func b(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%3d,%3d,%3d", b(c.r), b(c.g), b(c.b))
    }
}
#endif

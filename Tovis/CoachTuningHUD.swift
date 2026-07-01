// DEBUG-only tuning console for the AI-photographer coach. The device tune
// pass is edit-slider → watch-the-ring instead of edit-file → rebuild → re-aim:
// live raw signals (what the camera measures) on top, threshold sliders below,
// and "Copy values" to paste the tuned numbers back into CoachTuning.swift.
// Reached from the camera's coaching-settings sheet (Developer section).
#if DEBUG
import SwiftUI

struct CoachTuningHUD: View {
    let coach: CoachEngine
    @Environment(\.dismiss) private var dismiss
    /// Slider mutations don't touch SwiftUI state, so force refreshes.
    @State private var revision = 0

    /// Everything tunable from the console: title, slider range, and accessors
    /// onto the mutable CoachTuning statics.
    private struct Knob {
        let title: String
        let range: ClosedRange<Double>
        let get: () -> Double
        let set: (Double) -> Void
    }

    private static let knobs: [Knob] = [
        Knob(title: "readyThreshold", range: 0.4...1.0,
             get: { CoachTuning.readyThreshold }, set: { CoachTuning.readyThreshold = $0 }),
        Knob(title: "harvestThreshold", range: 0.5...1.0,
             get: { CoachTuning.harvestThreshold }, set: { CoachTuning.harvestThreshold = $0 }),
        Knob(title: "autoCaptureHoldSeconds", range: 0.2...2.0,
             get: { CoachTuning.autoCaptureHoldSeconds }, set: { CoachTuning.autoCaptureHoldSeconds = $0 }),
        Knob(title: "lumaTooDark", range: 0.05...0.4,
             get: { CoachTuning.lumaTooDark }, set: { CoachTuning.lumaTooDark = $0 }),
        Knob(title: "lumaTooBright", range: 0.6...0.95,
             get: { CoachTuning.lumaTooBright }, set: { CoachTuning.lumaTooBright = $0 }),
        Knob(title: "lumaIdeal", range: 0.3...0.65,
             get: { CoachTuning.lumaIdeal }, set: { CoachTuning.lumaIdeal = $0 }),
        Knob(title: "backlitFaceRatio", range: 0.3...0.9,
             get: { CoachTuning.backlitFaceRatio }, set: { CoachTuning.backlitFaceRatio = $0 }),
        Knob(title: "faceExposureBias (EV)", range: -1.5...0.5,
             get: { Double(CoachTuning.faceExposureBias) }, set: { CoachTuning.faceExposureBias = Float($0) }),
        Knob(title: "sharpnessReference", range: 0.02...0.4,
             get: { CoachTuning.sharpnessReference }, set: { CoachTuning.sharpnessReference = $0 }),
        Knob(title: "sharpnessSoft", range: 0.05...0.5,
             get: { CoachTuning.sharpnessSoft }, set: { CoachTuning.sharpnessSoft = $0 }),
        Knob(title: "sharpnessSlightlySoft", range: 0.1...0.7,
             get: { CoachTuning.sharpnessSlightlySoft }, set: { CoachTuning.sharpnessSlightlySoft = $0 }),
        Knob(title: "clutterReference", range: 0.02...0.5,
             get: { CoachTuning.clutterReference }, set: { CoachTuning.clutterReference = $0 }),
        Knob(title: "clutterBusy", range: 0.2...1.0,
             get: { CoachTuning.clutterBusy }, set: { CoachTuning.clutterBusy = $0 }),
        Knob(title: "minSubjectFill", range: 0.05...0.6,
             get: { CoachTuning.minSubjectFill }, set: { CoachTuning.minSubjectFill = $0 }),
        Knob(title: "mixedLightSpread", range: 0.02...0.4,
             get: { CoachTuning.mixedLightSpread }, set: { CoachTuning.mixedLightSpread = $0 }),
        Knob(title: "greenCastTint", range: 0.02...0.3,
             get: { CoachTuning.greenCastTint }, set: { CoachTuning.greenCastTint = $0 }),
        Knob(title: "warmCastWarmth", range: 0.05...0.6,
             get: { CoachTuning.warmCastWarmth }, set: { CoachTuning.warmCastWarmth = $0 }),
        Knob(title: "tiltBadDegrees", range: 2...15,
             get: { CoachTuning.tiltBadDegrees }, set: { CoachTuning.tiltBadDegrees = $0 }),
        Knob(title: "tiltWarnDegrees", range: 0.5...8,
             get: { CoachTuning.tiltWarnDegrees }, set: { CoachTuning.tiltWarnDegrees = $0 }),
        Knob(title: "qcSharpnessMin", range: 0.02...0.4,
             get: { CoachTuning.qcSharpnessMin }, set: { CoachTuning.qcSharpnessMin = $0 }),
        Knob(title: "lightMatchLumaTolerance", range: 0.02...0.25,
             get: { CoachTuning.lightMatchLumaTolerance }, set: { CoachTuning.lightMatchLumaTolerance = $0 }),
        Knob(title: "lightMatchWarmthTolerance", range: 0.02...0.25,
             get: { CoachTuning.lightMatchWarmthTolerance }, set: { CoachTuning.lightMatchWarmthTolerance = $0 }),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Live signals (−1 = no reading)") {
                    if coach.debugSignals.isEmpty {
                        Text("Waiting for frames… point the camera at the scene.")
                            .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                    }
                    ForEach(coach.debugSignals) { signal in
                        HStack {
                            Text(signal.name).font(BrandFont.mono(13))
                            Spacer()
                            Text(String(format: "%.3f", signal.value))
                                .font(BrandFont.mono(13))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    }
                }
                Section("Thresholds (live — copy back into CoachTuning.swift)") {
                    ForEach(Array(Self.knobs.enumerated()), id: \.offset) { _, knob in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(knob.title).font(BrandFont.mono(12))
                                Spacer()
                                Text(String(format: "%.3f", knob.get()))
                                    .font(BrandFont.mono(12))
                                    .foregroundStyle(BrandColor.accent)
                            }
                            Slider(
                                value: Binding(
                                    get: { knob.get() },
                                    set: { knob.set($0); revision += 1 }
                                ),
                                in: knob.range
                            )
                        }
                    }
                }
                Section {
                    Button("Copy values") {
                        UIPasteboard.general.string = Self.knobs
                            .map { "\($0.title) = \(String(format: "%.4f", $0.get()))" }
                            .joined(separator: "\n")
                    }
                }
            }
            .navigationTitle("Coach tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .tint(BrandColor.accent)
        .onAppear { CoachDebug.captureSignals = true }
        .onDisappear { CoachDebug.captureSignals = false }
    }
}
#endif

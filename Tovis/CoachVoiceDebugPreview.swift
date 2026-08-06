#if DEBUG
// DEBUG ONLY — a way to actually LOOK AT what `CameraLaneView` and
// `DimensionsDrawer` render for a personality pack, on a machine where the
// Simulator has no camera (`ProCapturePhotosView`'s camera stack dead-ends
// on "The camera didn't start" before either view is ever reached — see
// `CameraController`) and no CoreMotion (`LevelCoach`'s tilt nudges need a
// real device). Reached from `RootView` via `TOVIS_DEBUG_OPEN_COACH_PREVIEW`,
// same reasoning as `debugExport`/`debugCoachSettings`: no session, no
// booking, no camera required.
//
// Renders the SAME production `CameraLaneView`/`DimensionsDrawer`, fed
// `LaneMessage`/`CoachStatus` built from the SAME `CoachAggregate.evaluate`
// a real frame would produce — just with a hand-built `FrameContext`
// standing in for the camera.
import SwiftUI

struct CoachVoiceDebugPreview: View {
    @State private var settings = CoachSettings()

    private var voice: CoachVoice { settings.personality.voice }

    private static let coaches: [ShotCoach] = [
        LightingCoach(), CompositionCoach(), SharpnessCoach(),
        BackgroundCoach(), PoseCoach(), LevelCoach(), ColorCoach(),
    ]
    private static let face = CGRect(x: 0.35, y: 0.15, width: 0.30, height: 0.25)
    private static let pose = PoseSignal(edgeClipped: false, joints: [
        .leftShoulder: CGPoint(x: 0.32, y: 0.48), .rightShoulder: CGPoint(x: 0.68, y: 0.48),
    ])

    private static func ctx(
        luma: Double = 0.47, faceLuma: Double? = nil, backgroundLuma: Double? = 0.5,
        mixed: Double = 0, clutter: Double = 0, tilt: Double = 0
    ) -> FrameContext {
        FrameContext(avgLuma: luma, faceBounds: face, faceLuma: faceLuma ?? luma,
                    backgroundLuma: backgroundLuma, sharpness: 0.6, backgroundClutter: clutter,
                    subjectFill: 0.5, pose: pose, deviceTilt: tilt,
                    color: ColorSignal(mixed: mixed, greenTint: 0, warmth: 0.15),
                    expectations: .portrait)
    }

    /// One frame per moment worth eyeballing — the same fixtures the
    /// guardrail test (`CoachVoiceGuardrailTests`) uses, so what's on screen
    /// here and what the test pins are the same frames.
    private static let frames: [(label: String, ctx: FrameContext)] = [
        // `backgroundLuma` explicit and equal to `faceLuma` — the default
        // (0.5) makes 0.10 read as BACKLIT (0.10 < 0.5 × 0.6), not too dark.
        ("too dark", ctx(luma: 0.10, faceLuma: 0.10, backgroundLuma: 0.10)),
        ("backlit", ctx(luma: 0.36, faceLuma: 0.24, backgroundLuma: 0.42)),
        ("tilted (bad)", ctx(tilt: 8)),
        ("tilted (almost level)", ctx(tilt: 4)),
        ("mixed light + busy background", ctx(mixed: 0.20, clutter: 0.70)),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Coach personality", selection: $settings.personality) {
                        ForEach(CoachPersonality.allCases) { p in Text(p.displayName).tag(p) }
                    }
                    .pickerStyle(.segmented)

                    group("Resting states") {
                        labeled("hold-still / auto-capture") {
                            lane(CameraLane.Inputs(isReady: true))
                        }
                        labeled("great-shot celebration") {
                            lane(CameraLane.Inputs(setComplete: true))
                        }
                        labeled("calibration drift") {
                            lane(CameraLane.Inputs(lightDrifted: true))
                        }
                    }

                    group("Coach tip, per moment") {
                        ForEach(Self.frames, id: \.label) { frame in
                            labeled(frame.label) { lane(forFrame: frame.ctx) }
                        }
                    }

                    group("Dimensions drawer (live while open, so this is a snapshot)") {
                        DimensionsDrawer(headline: "Preview", headlineTone: .warn,
                                         statuses: sampleStatuses, voice: voice)
                            .frame(minHeight: 560)
                            .background(BrandColor.bgSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle(settings.personality.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func lane(_ inputs: CameraLane.Inputs) -> some View {
        CameraLaneView(message: CameraLane.message(inputs, voice: voice), backgroundBusy: false,
                       onAction: { _ in }, onExpand: {}, accessibilityValue: "")
    }

    private func lane(forFrame frame: FrameContext) -> some View {
        let verdict = CoachAggregate.evaluate(Self.coaches, frame)
        var inputs = CameraLane.Inputs()
        inputs.coachTip = verdict.nudge?.message
        inputs.coachTipMoment = verdict.nudge?.moment
        inputs.coachTipPhraseCtx = verdict.nudge?.phraseCtx
        inputs.hasDimensions = true
        return lane(inputs)
    }

    /// One issue per category where the fixtures above produce one, good
    /// otherwise — enough variety to see the issue phrasing, the goodPhrase
    /// fallback, and the why-gating together on one screen.
    private var sampleStatuses: [CoachStatus] {
        let dark = CoachAggregate.evaluate(Self.coaches, Self.ctx(luma: 0.10, faceLuma: 0.10, backgroundLuma: 0.10)).statuses
        let tilted = CoachAggregate.evaluate(Self.coaches, Self.ctx(tilt: 8)).statuses
        let mixedBusy = CoachAggregate.evaluate(Self.coaches, Self.ctx(mixed: 0.20, clutter: 0.70)).statuses
        let good = CoachAggregate.evaluate(Self.coaches, Self.ctx()).statuses
        func pick(_ category: CoachCategory, from pool: [CoachStatus]) -> CoachStatus {
            pool.first { $0.category == category } ?? good.first { $0.category == category }!
        }
        return [
            pick(.lighting, from: dark),
            pick(.color, from: mixedBusy),
            pick(.level, from: tilted),
            pick(.composition, from: good),
            pick(.sharpness, from: good),
            pick(.background, from: mixedBusy),
            pick(.pose, from: good),
        ]
    }
}
#endif

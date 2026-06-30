// The persistent 4-step rail shown across the session flow (Consult · Before ·
// Service · Wrap-up) — the native port of the web `StepRows` /
// `brand-pro-session-rail`. A step's connecting tracks turn accent once it's
// done; the active step's dot glows. Driven by `ProSessionFlow.stepItems`.
import SwiftUI
import TovisKit

struct ProSessionStepRail: View {
    let effectiveStep: SessionStep

    private var items: [ProSessionStepItem] {
        ProSessionFlow.stepItems(effectiveStep: effectiveStep)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, step in
                VStack(spacing: 6) {
                    ZStack {
                        // Connecting tracks (hidden on the outer edges).
                        HStack(spacing: 0) {
                            track(on: step.state == .done, hidden: index == 0)
                            Spacer().frame(width: 28)
                            track(on: step.state == .done, hidden: index == items.count - 1)
                        }
                        dot(step)
                    }
                    Text(step.label)
                        .font(BrandFont.mono(10))
                        .tracking(0.6)
                        .foregroundStyle(
                            step.state == .idle ? BrandColor.textMuted : BrandColor.textSecondary
                        )
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private func track(on: Bool, hidden: Bool) -> some View {
        Rectangle()
            .fill(hidden ? Color.clear : (on ? BrandColor.accent : BrandColor.textMuted.opacity(0.25)))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func dot(_ step: ProSessionStepItem) -> some View {
        let fill: Color = {
            switch step.state {
            case .done: return BrandColor.accent
            case .active: return BrandColor.accent.opacity(0.18)
            case .idle: return BrandColor.bgSecondary
            }
        }()

        ZStack {
            Circle().fill(fill)
            if step.state == .active {
                Circle().stroke(BrandColor.accent, lineWidth: 2)
            }
            if step.state == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(BrandColor.onAccent)
            } else {
                Text("\(step.number)")
                    .font(BrandFont.body(12, .bold))
                    .foregroundStyle(
                        step.state == .active ? BrandColor.accent : BrandColor.textMuted
                    )
            }
        }
        .frame(width: 28, height: 28)
    }
}

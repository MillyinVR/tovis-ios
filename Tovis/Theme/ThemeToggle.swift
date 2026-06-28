// System / Light / Dark segmented control — a native port of the web's
// `lib/brand/ThemeToggle.tsx`: a pill radiogroup with mono-uppercase labels and
// an accent-filled active segment. Writes through ThemeStore so the whole app
// re-themes instantly.
import SwiftUI

struct ThemeToggle: View {
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ThemePreference.allCases) { option in
                let active = theme.preference == option

                Button {
                    theme.preference = option
                } label: {
                    Text(option.label.uppercased())
                        .font(BrandFont.mono(11))
                        .tracking(1.5)
                        .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(active ? BrandColor.accent : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(4)
        .overlay(
            Capsule().stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
        )
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color theme")
    }
}
// Shared brand-styled building blocks reused across the signed-in screens
// (home, appointments, detail). Keeping them here avoids re-implementing the
// same surface/pill/avatar/section in every view.
import SwiftUI

/// A rounded surface — the standard card/row container.
struct BrandSurface<Content: View>: View {
    var tint: Color = BrandColor.bgSurface
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
            )
    }
}

/// A small capsule label (duration, price, status …).
struct BrandPill: View {
    let text: String
    var tint: Color = BrandColor.textMuted

    var body: some View {
        Text(text)
            .font(BrandFont.mono(11))
            .foregroundStyle(tint)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

/// A circular avatar: the pro's photo when present, else their initial on a
/// branded chip. Works for any source — pass a resolved display name.
struct BrandAvatar: View {
    let name: String
    var avatarUrl: String? = nil
    let size: CGFloat

    var body: some View {
        Group {
            if let urlString = avatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1))
    }

    private var placeholder: some View {
        ZStack {
            BrandColor.bgSecondary
            Text(initial)
                .font(BrandFont.display(size * 0.36, .semibold))
                .foregroundStyle(BrandColor.accent)
        }
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        return String(trimmed.prefix(1)).uppercased()
    }
}

/// A titled section with an optional trailing note.
struct BrandSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(BrandFont.display(18, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(BrandFont.mono(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
            content
        }
    }
}

/// Tone for a booking status chip — keeps status coloring consistent everywhere.
func statusTone(_ status: String?) -> Color {
    switch (status ?? "").uppercased() {
    case "ACCEPTED", "CONFIRMED", "COMPLETED": return BrandColor.emerald
    case "PENDING", "CONSULTATION": return BrandColor.gold
    case "CANCELLED": return BrandColor.ember
    default: return BrandColor.textMuted
    }
}

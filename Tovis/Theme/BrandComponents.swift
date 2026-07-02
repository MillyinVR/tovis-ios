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

/// A section with a small mono-uppercase eyebrow label — matches the web's
/// section headers (`font-mono text-[10px] uppercase tracking-[0.16em]
/// text-textMuted`). An optional trailing count renders as "· N", as on web.
struct BrandSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(BrandFont.mono(11))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(BrandColor.textMuted)
            content
        }
    }

    private var label: String {
        guard let trailing else { return title }
        return "\(title) · \(trailing)"
    }
}

/// A left-aligned wrapping layout (like CSS `flex-wrap`): lays children out in
/// rows, wrapping to the next line when the current row is full. Used for pill
/// rows (accepted payments, tags) that must wrap on narrow screens.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
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

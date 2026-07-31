// Shared brand-styled building blocks reused across the signed-in screens
// (home, appointments, detail). Keeping them here avoids re-implementing the
// same surface/pill/avatar/section in every view.
import SwiftUI
import TovisKit

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

/// An inline error banner for a failed ACTION — the write-error channel for
/// screens whose `phase` only models load failures. Inline rather than an
/// alert/sheet on purpose: it keeps the list on screen, and several of these
/// views already carry `.sheet` modifiers that a second presentation would
/// contend with.
struct BrandErrorBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(BrandColor.ember.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
///
/// The booking states themselves come from `BookingStatusPresentation.tone`, the
/// same table web tones from (B10): IN_PROGRESS and NO_SHOW used to miss every
/// arm here and render in `textMuted`, so a live session and a missed
/// appointment were the same grey as the pro's own blocked time.
func statusTone(_ status: String?) -> Color {
    switch (status ?? "").uppercased() {
    // Not booking statuses: a session STEP, and a client's live checkout
    // reservation on the pro calendar (B5). The hold shares the provisional
    // tone with PENDING — it is in-flight, not committed — and must NOT fall
    // through to `textMuted`, which is the pro's own blocked time.
    case "CONSULTATION", "HELD": return BrandColor.gold
    default: break
    }

    switch BookingStatusPresentation.tone(status) {
    case .pending: return BrandColor.gold
    case .active, .done: return BrandColor.emerald
    case .ended: return BrandColor.ember
    case .unknown: return BrandColor.textMuted
    }
}

/// Color for a server-derived badge's wire tone — the web `Badge` tone
/// vocabulary, consumed verbatim (the state is never recomputed on device).
/// Shared by K1's `paymentBadge.tone` and K5's `relationshipBadge.tone`: both
/// come from the same web vocabulary, so they get ONE table, not one each.
/// Lives here next to `statusTone` (the B10 seam) so no screen grows its own
/// badge palette. An unrecognized tone reads muted, never loud.
func wireBadgeTone(_ tone: String?) -> Color {
    switch tone {
    case "danger": return BrandColor.ember
    case "success": return BrandColor.emerald
    case "warn": return BrandColor.amber
    case "pending": return BrandColor.gold
    case "info": return BrandColor.iris
    case "accent": return BrandColor.accent
    default: return BrandColor.textMuted  // "neutral" + anything unknown
    }
}

/// Colour for a booking's SERVICE swatch (K7–K9) — the pro's own colour for the
/// service, painted on a calendar tile's leading stripe and nowhere else
/// (decision D2: status keeps the fill).
///
/// Returns **nil**, not a fallback colour, when the booking has no swatch or
/// carries one this build's palette doesn't define. nil means "this channel is
/// unclaimed" and the caller keeps whatever the stripe already showed — a
/// service colour nobody picked would be a lie about which service the booking
/// is, and a substituted hue would be a lie about which colour they picked.
///
/// Lives here beside `statusTone` and `wireBadgeTone` (the B10 seam) so the grid
/// views never grow a second colour system.
func calendarSwatchTone(_ id: String?) -> Color? {
    guard let id else { return nil }
    return BrandColor.calendarSwatches[id]
}

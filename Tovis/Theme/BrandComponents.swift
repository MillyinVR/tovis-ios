// Shared brand-styled building blocks reused across the signed-in screens
// (home, appointments, detail). Keeping them here avoids re-implementing the
// same surface/pill/avatar/section in every view.
import SwiftUI
import TovisKit

/// Width presets for `.cappedWidth(_:)` — the two shapes content on this app
/// actually needs on a regular-width (iPad) canvas. Named rather than passed
/// as raw numbers at each call site, so every screen that wants "the reading
/// column" gets the SAME column, not five close-but-different guesses.
enum AdaptiveWidth {
    /// A portrait media column — the full-bleed Looks pager, sized like a
    /// large phone screen so a paged photo/video doesn't stretch into
    /// something no phone camera actually shoots.
    static let feed: CGFloat = 480
    /// A comfortable reading/form column — look detail, settings, bookings:
    /// anything that is fundamentally a scrolling list or form rather than a
    /// grid, where iPad's extra width is line-length, not more content.
    static let reading: CGFloat = 700
}

/// Caps a view's width and centers it when the environment reports a
/// `.regular` horizontal size class (iPad, and an iPhone Plus/Max in
/// landscape — the same test `HomeView` already uses for its two-column
/// layout) — a no-op everywhere else, so iPhone portrait is untouched byte
/// for byte.
///
/// This is the general form of the "don't stretch across the whole canvas"
/// fix: `BookingFlowView` gets an equivalent cap for free from SwiftUI's own
/// sheet presentation on iPad, but a screen that ISN'T a sheet root — a tab's
/// own content, or anything reached by a plain `NavigationLink` push onto a
/// stack that's already on screen — gets no such cap from the system and has
/// to ask for one explicitly. Applying it INSIDE the view itself (rather than
/// leaning on however it happens to be presented) means the same screen reads
/// right whether it's pushed, sheeted, or reached with a debug hook.
private struct RegularWidthCapped: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                content.frame(maxWidth: maxWidth)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }
}

extension View {
    /// See `RegularWidthCapped`. Pass an `AdaptiveWidth` preset so every
    /// caller draws from the same two column widths.
    func cappedWidth(_ maxWidth: CGFloat) -> some View {
        modifier(RegularWidthCapped(maxWidth: maxWidth))
    }
}

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
    /// How each WRAPPED ROW sits in the available width.
    ///
    /// `.leading` (the default, and what every existing caller gets) packs rows
    /// to the left, which leaves a lone trailing chip stranded in the corner —
    /// four tip chips wrap 3 + 1, and the orphan reads as a mistake rather than
    /// as the last option. `.center` balances each row instead.
    var rowAlignment: HorizontalAlignment = .leading

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
        // Group into rows FIRST. Centering needs a row's total width before any
        // of its members can be placed, which a single streaming pass can't know.
        var rows: [[(index: Int, size: CGSize)]] = []
        var row: [(index: Int, size: CGSize)] = []
        var rowWidth: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let widthWithThis = rowWidth + (row.isEmpty ? 0 : spacing) + size.width
            if !row.isEmpty, widthWithThis > bounds.width {
                rows.append(row)
                row = [(index, size)]
                rowWidth = size.width
            } else {
                row.append((index, size))
                rowWidth = widthWithThis
            }
        }
        if !row.isEmpty { rows.append(row) }

        var y = bounds.minY
        for row in rows {
            let contentWidth = row.reduce(CGFloat(0)) { $0 + $1.size.width }
                + spacing * CGFloat(max(0, row.count - 1))
            var x = bounds.minX
            if rowAlignment == .center {
                x += max(0, (bounds.width - contentWidth) / 2)
            } else if rowAlignment == .trailing {
                x += max(0, bounds.width - contentWidth)
            }

            var rowHeight: CGFloat = 0
            for item in row {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
                rowHeight = max(rowHeight, item.size.height)
            }
            y += rowHeight + lineSpacing
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

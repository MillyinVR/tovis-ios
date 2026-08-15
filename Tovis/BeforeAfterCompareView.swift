// The transformation payoff — an interactive before/after comparison slider. The
// "after" fills the frame; the "before" is revealed up to a draggable divider.
// Before/after is the engine of beauty content, so the pro (and later a published
// Look) gets a clean way to see — and show — the result.
import SwiftUI

struct BeforeAfterCompareView: View {
    let beforeURL: URL
    let afterURL: URL
    var height: CGFloat = 400
    /// Corner radius of the clipped frame. Defaults to 16 (the standalone card
    /// look); pass 0 to sit flush in a sharp-cornered grid cell.
    var cornerRadius: CGFloat = 16
    /// Fill the parent instead of the fixed `height` — used by the full-screen
    /// Looks feed slide (which owns its own sizing).
    var fillContainer: Bool = false
    /// Only claim *horizontal* drags, letting vertical gestures fall through to
    /// a scrolling ancestor (the Looks feed's vertical pager). When false (the
    /// default, for grid/detail tiles that don't scroll under the slider) the
    /// wipe owns every drag the instant a finger lands — parity with web's
    /// `passVerticalScroll` prop on BeforeAfterReveal.
    var passVerticalScroll: Bool = false
    /// Whether the divider can be dragged.
    ///
    /// 🔴 `false` where the comparison sits INSIDE a scrolling page. An
    /// interactive slider claims the drag the instant a finger lands — and
    /// `passVerticalScroll` is not enough, because an exclusive DragGesture is
    /// still RECOGNISED and the scroll view never sees the pan. A tall slider
    /// then becomes a stretch of page you cannot scroll past. The static form
    /// shows the same split (and is what the design frame draws); the draggable
    /// one lives on the look detail, one tap away.
    var interactive: Bool = true

    /// How much of the "before" is revealed from the left, 0…1.
    @State private var fraction: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                fullImage(afterURL, size: geo.size)

                // The before, same full-size image, masked to the left of the divider
                // so the two stay pixel-aligned as the divider moves.
                fullImage(beforeURL, size: geo.size)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(0, w * fraction))
                    }

                label("BEFORE", align: .leading).opacity(fraction > 0.12 ? 1 : 0)
                label("AFTER", align: .trailing).opacity(fraction < 0.88 ? 1 : 0)

                // Divider, plus the grab handle only when it can actually be
                // grabbed — a handle on a static split invites a drag that does
                // nothing.
                divider
                    .position(x: max(0, min(w, w * fraction)), y: geo.size.height / 2)
                    .opacity(interactive ? 1 : 0)

                if !interactive {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2)
                        .position(x: max(0, min(w, w * fraction)), y: geo.size.height / 2)
                        .frame(height: geo.size.height)
                }
            }
            .contentShape(Rectangle())
            // Non-interactive mode attaches NO gesture at all — see `interactive`.
            .gesture(interactive ? dragGesture(width: w) : nil)
        }
        .frame(height: fillContainer ? nil : height)
        .frame(maxWidth: fillContainer ? .infinity : nil,
               maxHeight: fillContainer ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// In passVerticalScroll mode the drag needs a small minimum distance and
    /// only tracks once the movement is horizontal-dominant — so a vertical
    /// swipe stays with the pager instead of dragging the divider.
    private func dragGesture(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: passVerticalScroll ? 10 : 0)
            .onChanged { value in
                if passVerticalScroll,
                   abs(value.translation.height) > abs(value.translation.width) {
                    return
                }
                guard w > 0 else { return }
                fraction = min(1, max(0, value.location.x / w))
            }
    }

    private func fullImage(_ url: URL, size: CGSize) -> some View {
        // Bounded decode — these are ORIGINAL uploads; two full-resolution
        // AsyncImage decodes side by side is a jetsam-sized allocation.
        DownsampledRemoteImage(url: url) {
            ZStack { BrandColor.bgSecondary; ProgressView().tint(BrandColor.accent) }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var divider: some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 2)
            Circle().fill(.white).frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(BrandColor.accent)
                )
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        }
    }

    private func label(_ text: String, align: Alignment) -> some View {
        Text(text)
            .font(BrandFont.mono(11)).tracking(1).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align == .leading ? .topLeading : .topTrailing)
    }
}


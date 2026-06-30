// The transformation payoff — an interactive before/after comparison slider. The
// "after" fills the frame; the "before" is revealed up to a draggable divider.
// Before/after is the engine of beauty content, so the pro (and later a published
// Look) gets a clean way to see — and show — the result.
import SwiftUI

struct BeforeAfterCompareView: View {
    let beforeURL: URL
    let afterURL: URL
    var height: CGFloat = 400

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

                // Divider + grab handle.
                divider.position(x: max(0, min(w, w * fraction)), y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in fraction = min(1, max(0, value.location.x / w)) }
            )
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func fullImage(_ url: URL, size: CGSize) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
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

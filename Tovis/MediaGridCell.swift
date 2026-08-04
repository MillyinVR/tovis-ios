// The one place a media grid decides how big a cell is.
//
// 🔴 Why this exists — the bug it was extracted to kill:
//
// A grid cell used to be built by putting the image in a ZStack and pinning the
// stack's height:
//
//     ZStack { placeholder; AsyncImage { $0.resizable().scaledToFill() } }
//         .frame(height: 120)
//         .clipShape(RoundedRectangle(cornerRadius: 12))
//
// `scaledToFill` is an ASPECT-RATIO modifier, not a crop: given a proposal it
// reports back the size it needs in order to cover that proposal, which for a
// landscape source is WIDER than the proposal. A ZStack reports the union of its
// children, and `.frame(height:)` only pins the height — so the cell's WIDTH
// became a function of the source image's aspect ratio. A 4032×3024 upload in a
// 114pt column reported ~146pt, drew centred, and spilled ~16pt over each
// neighbour. Every source aspect produced a different width, so the row was both
// overlapping and uneven. `.clipShape` could not save it: by then the view's
// bounds were already the overflowing ones.
//
// The fix is structural. The cell's size comes from a `Color.clear` sized by the
// grid column and an explicit aspect ratio; the media rides in an `.overlay`.
// An overlay is measured AGAINST its parent and never contributes to the
// parent's size, so however extreme the source's aspect, the cell stays exactly
// one column wide and one ratio tall — and `.clipped()` then crops the overflow
// that `scaledToFill` deliberately produces.
//
// Everything that renders a uniform media grid goes through here so the failure
// can't be reintroduced in one screen and not the others.
import SwiftUI

/// The geometry a uniform media grid shares.
enum MediaGridLayout {
    /// Portrait 3:4 — the ratio the web portfolio grid crops to, and the ratio a
    /// look tile already uses natively (`LookGridCard`).
    static let portraitAspect: CGFloat = 3.0 / 4.0
    /// Square — the management and review grids, where the tile is an inventory
    /// thumbnail rather than a client-facing crop.
    static let squareAspect: CGFloat = 1.0

    /// Equal flexible columns. Every grid builds its columns here so a cell's
    /// width is always "the container, minus the gaps, divided evenly" — never
    /// something a piece of content got to vote on.
    static func columns(count: Int, spacing: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    /// The width one cell gets. Pure arithmetic, exposed so the no-overflow
    /// invariant is testable without rendering.
    static func columnWidth(container: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let gaps = spacing * CGFloat(count - 1)
        return max(0, (container - gaps) / CGFloat(count))
    }

    /// The size `scaledToFill` hands back for `source` asked to cover `cell` —
    /// i.e. exactly what the cell has to clip away. Kept next to the layout it
    /// explains: the whole point of the structure above is that this size, which
    /// is a function of the CONTENT, never reaches the cell's own geometry.
    static func filledContentSize(source: CGSize, in cell: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0, cell.width > 0, cell.height > 0 else { return cell }
        let scale = max(cell.width / source.width, cell.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

/// A grid cell whose size is decided by the GRID, not by what is inside it.
///
/// The content is laid out as an overlay, so it may be any aspect ratio — an
/// image told to `scaledToFill`, a before/after slider, a placeholder — without
/// ever changing the cell's footprint.
struct MediaGridCell<Content: View>: View {
    var aspectRatio: CGFloat = MediaGridLayout.portraitAspect
    var cornerRadius: CGFloat = 12
    /// Filled behind the content so a slow or missing image still occupies a
    /// full, correctly-sized cell rather than collapsing the row.
    var background: Color = BrandColor.bgSecondary
    @ViewBuilder var content: () -> Content

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .background(background)
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// A remote image cropped to fill its cell. Always used INSIDE `MediaGridCell`,
/// where `scaledToFill`'s overflow is harmless and gets clipped.
struct MediaGridImage: View {
    let url: URL?
    var body: some View {
        if let url {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ProgressView().tint(BrandColor.accent)
            }
        }
    }
}

/// A before/after comparison slider sized to a grid cell.
///
/// `BeforeAfterCompareView` wants an explicit pixel height, so it reads the cell
/// back out of a `GeometryReader` rather than guessing — which is what keeps a
/// paired tile exactly the same size as the plain tile beside it. Before this was
/// shared, the pro's own portfolio passed a hard-coded `height: 120` while the
/// public grid measured the cell, so the two kinds of tile in the SAME row came
/// out different sizes.
struct MediaGridCompareCell: View {
    let beforeURL: URL
    let afterURL: URL
    var aspectRatio: CGFloat = MediaGridLayout.portraitAspect
    var cornerRadius: CGFloat = 12

    var body: some View {
        MediaGridCell(aspectRatio: aspectRatio, cornerRadius: cornerRadius) {
            GeometryReader { geo in
                BeforeAfterCompareView(
                    beforeURL: beforeURL,
                    afterURL: afterURL,
                    height: geo.size.height,
                    cornerRadius: 0
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

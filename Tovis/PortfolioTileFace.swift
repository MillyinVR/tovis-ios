// One portfolio tile's face — the media, its crop, and its badges.
//
// A portfolio tile looks the same wherever it appears: the pro's own Profile tab
// and the public pro profile render the same `ProPortfolioTile` list, and used to
// do it with two hand-rolled copies. The copies drifted — the public grid cropped
// every tile to a uniform 3:4, the pro's own grid pinned a bare height and let the
// source image size its own cell (see `MediaGridCell` for what that cost) — so the
// pro saw an overlapping, uneven grid on the one screen they look at most.
//
// What legitimately differs between the two surfaces is chrome and corner radius,
// so that is all this takes as a parameter. Sizing is not negotiable and lives in
// `MediaGridCell`.
import SwiftUI
import TovisKit

struct PortfolioTileFace: View {
    let tile: ProPortfolioTile
    /// Corner radius of the cell — 12 for the pro's spaced grid, 0 for the
    /// public profile's flush 2pt-gutter mosaic.
    var cornerRadius: CGFloat = 12
    /// Badge set to draw over the media.
    var chrome: Chrome = .videoGlyph
    /// Whether this is the grid's first tile — only the first one may wear the
    /// "FEAT" chip, matching the web grid.
    var isFirst: Bool = false

    enum Chrome {
        /// A centred play glyph and nothing else (the pro's own portfolio tab).
        case videoGlyph
        /// FEAT · VIDEO · SERVICE capsules (the public profile grid).
        case chips
    }

    // Badges hang off the CELL, not off the image. The image inside deliberately
    // overflows (that is what fill-cropping means), so anchoring a chip to it
    // would push the chip out past the cell's edge and into the clip.
    var body: some View {
        MediaGridCell(cornerRadius: cornerRadius) {
            MediaGridImage(url: URL(string: tile.displayUrl))
        }
        .overlay { glyph }
        .overlay(alignment: .topLeading) { featChip }
        .overlay(alignment: .topTrailing) { videoChip }
        .overlay(alignment: .bottomLeading) { serviceChip }
    }

    @ViewBuilder
    private var glyph: some View {
        if case .videoGlyph = chrome, tile.isVideo {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    @ViewBuilder
    private var featChip: some View {
        if case .chips = chrome, isFirst, tile.isFeaturedInPortfolio {
            chip("★ FEAT", tint: BrandColor.iris).padding(6)
        }
    }

    @ViewBuilder
    private var videoChip: some View {
        if case .chips = chrome, tile.isVideo {
            chip("VIDEO", tint: .white).padding(6)
        }
    }

    @ViewBuilder
    private var serviceChip: some View {
        if case .chips = chrome, !tile.serviceIds.isEmpty {
            chip("SERVICE", tint: .white).padding(6)
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(BrandFont.mono(9))
            .foregroundStyle(tint)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

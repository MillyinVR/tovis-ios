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
    /// See `MediaGridImage.showsSpinner` — the public profile's mosaic loads
    /// into a plain fill, the pro's spaced grid into a spinner.
    var showsSpinner: Bool = true

    enum Chrome {
        /// A centred play glyph and nothing else (the pro's own portfolio tab).
        case videoGlyph
        /// The public profile's feed grid: a scrim, the likes/comments counts,
        /// and the B/A · video · recreate flags.
        case chips
    }

    // Badges hang off the CELL, not off the image. The image inside deliberately
    // overflows (that is what fill-cropping means), so anchoring a chip to it
    // would push the chip out past the cell's edge and into the clip.
    var body: some View {
        MediaGridCell(cornerRadius: cornerRadius) {
            MediaGridImage(
                url: URL(string: tile.displayUrl),
                // One crop per look, applied EVERYWHERE: the tile shows the frame
                // the pro published, not a 3:4 window derived from the master.
                display: tile.displayCrop,
                showsSpinner: showsSpinner
            )
        }
        .overlay { glyph }
        .overlay { scrim }
        .overlay(alignment: .topLeading) { recreatedChip }
        .overlay(alignment: .topTrailing) { kindChip }
        .overlay(alignment: .bottom) { counts }
    }

    @ViewBuilder
    private var glyph: some View {
        if case .videoGlyph = chrome, tile.isVideo {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    /// Top-and-bottom darkening so the counts stay legible on a bright photo.
    /// This sits over a PHOTOGRAPH in both appearances, so it is fixed black and
    /// the text on it is fixed white — a theme-following pair would go pale-on-pale
    /// in light mode.
    @ViewBuilder
    private var scrim: some View {
        if case .chips = chrome {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.20), location: 0),
                    .init(color: .clear, location: 0.34),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.62), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    // 🔴 There is no "★ FEAT" chip here any more. It was gated on
    // `isFirst && tile.isFeaturedInPortfolio` — and that flag is true of EVERY
    // tile the public grid renders, so it only ever meant "first in a
    // newest-first list", dressed up as a curated pick. The pro's real, chosen
    // highlight is `ProProfile.signature`, promoted above this grid.

    /// "N recreated this", count only. Zero renders NOTHING — never a "0".
    @ViewBuilder
    private var recreatedChip: some View {
        if case .chips = chrome, tile.engagement.recreatedCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8, weight: .bold))
                Text("\(tile.engagement.recreatedCount)")
                    .font(BrandFont.mono(9))
            }
            .foregroundStyle(BrandColor.gold)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
            .accessibilityLabel("\(tile.engagement.recreatedCount) recreated this")
        }
    }

    @ViewBuilder
    private var kindChip: some View {
        if case .chips = chrome {
            if tile.before != nil {
                chip("B / A", tint: .white).padding(6)
            } else if tile.isVideo {
                chip("VIDEO", tint: .white).padding(6)
            }
        }
    }

    @ViewBuilder
    private var counts: some View {
        if case .chips = chrome {
            HStack(spacing: 9) {
                countLabel(systemImage: "heart.fill", value: tile.engagement.likeCount)
                countLabel(systemImage: "bubble.left.fill", value: tile.engagement.commentCount)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 6)
        }
    }

    private func countLabel(systemImage: String, value: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 8))
            Text("\(value)").font(BrandFont.mono(10))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
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

// The shared 2-column looks grid — web LooksBookableGrid's layout — extracted
// from DiscoverView so the tag feed (LookTagFeedView) doesn't hand-roll a second
// copy. `LooksGrid` owns only the loaded case (tiles + the load-more affordance);
// loading/empty/error states stay with each screen, whose copy differs.

import SwiftUI
import TovisKit

/// A look tile — image with focal-aware crop, category badge, pro name/service —
/// whose overlay chrome matches what the tap does. Mirrors web LooksBookableGrid's
/// card (`.book`) and the tag page's plain tile (`.open`).
struct LookGridCard: View {
    /// What the card's overlay affordance says the tap will do.
    enum CTA {
        /// Discover's tap-anywhere-to-book card: price badge + accent "Book"
        /// pill (with a spinner while the booking offer resolves).
        case book(resolving: Bool)
        /// The tag feed's browse card: no booking chrome — the tap opens the
        /// look detail, where booking lives (web parity: tag tiles link to
        /// /looks/{id}).
        case open
    }

    let look: LooksFeedItem
    let cta: CTA
    let action: () -> Void

    private var proName: String { look.professional?.displayName ?? "Pro" }
    private var tag: String? { look.category ?? look.serviceName }
    private var serviceLabel: String? { look.serviceName ?? look.caption }

    private var isBook: Bool {
        if case .book = cta { return true }
        return false
    }

    private var isResolving: Bool {
        if case let .book(resolving) = cta { return resolving }
        return false
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let url = (look.thumbUrl ?? look.url).flatMap(URL.init(string:)) {
                            // Focal-aware cover crop (camera C6c) — center the 3:4
                            // tile on the subject; null focal → centered fill.
                            FocalCoverImage(url: url, focal: look.focalPoint) { CardSheen() }
                        } else {
                            CardSheen()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(3.0 / 4.0, contentMode: .fill)
                    .clipped()

                    LinearGradient(colors: [.clear, BrandColor.bgPrimary.opacity(0.6)],
                                   startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)

                    if let tag {
                        Text(tag.uppercased())
                            .font(BrandFont.mono(9)).tracking(1)
                            .foregroundStyle(BrandColor.textPrimary)
                            .padding(.vertical, 4).padding(.horizontal, 7)
                            .background(BrandColor.bgPrimary.opacity(0.7),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(6)
                    }

                    if isBook {
                        VStack {
                            HStack {
                                Spacer()
                                if let price = look.priceLabel {
                                    Text("FROM \(price)")
                                        .font(BrandFont.mono(9)).tracking(0.6)
                                        .foregroundStyle(BrandColor.textPrimary)
                                        .padding(.vertical, 4).padding(.horizontal, 7)
                                        .background(BrandColor.bgPrimary.opacity(0.7), in: Capsule())
                                }
                            }
                            Spacer()
                            HStack {
                                Spacer()
                                HStack(spacing: 5) {
                                    if isResolving {
                                        ProgressView().controlSize(.mini).tint(BrandColor.onAccent)
                                    }
                                    Text("Book")
                                        .font(BrandFont.mono(10)).tracking(0.6)
                                        .foregroundStyle(BrandColor.onAccent)
                                }
                                .padding(.vertical, 6).padding(.horizontal, 12)
                                .background(BrandColor.accent, in: Capsule())
                            }
                        }
                        .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(proName)
                        .font(BrandFont.body(12, .black)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
                    if let serviceLabel {
                        Text(serviceLabel)
                            .font(BrandFont.body(11, .semibold)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                    }
                }
                .padding(10)
            }
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isBook
                ? "Book \(serviceLabel ?? "this look") with \(proName)"
                : "\(serviceLabel ?? "Look") by \(proName)"
        )
    }
}

/// The grid + its load-more button. Emits one view (internal 16pt spacing keeps
/// DiscoverView's pre-extraction layout byte-identical).
struct LooksGrid: View {
    let looks: [LooksFeedItem]
    let cta: (LooksFeedItem) -> LookGridCard.CTA
    let action: (LooksFeedItem) -> Void
    let nextCursor: String?
    let loadingMore: Bool
    let onLoadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(looks) { look in
                    LookGridCard(look: look, cta: cta(look)) { action(look) }
                }
            }

            if nextCursor != nil {
                Button { onLoadMore() } label: {
                    Text(loadingMore ? "Loading…" : "Load more")
                        .font(BrandFont.mono(11)).tracking(0.8)
                        .foregroundStyle(BrandColor.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(BrandColor.bgPrimary.opacity(0.25), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(loadingMore)
                .padding(.top, 8)
            }
        }
    }
}

/// The placeholder sheen behind a loading/absent tile image. Shared by the grid
/// card and DiscoverView's other cards (trending pros, map callouts).
struct CardSheen: View {
    var body: some View {
        ZStack {
            BrandColor.bgPrimary.opacity(0.45)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.08), location: 0.0),
                    .init(color: .white.opacity(0.02), location: 0.35),
                    .init(color: .black.opacity(0.24), location: 1.0),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}

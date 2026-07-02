// Pro Reviews — the native counterpart of the web `/pro/reviews`, backed by
// GET /api/v1/pro/reviews (tovis-app PR #438). The 100 most recent reviews with
// star rating, headline/body, client + date, and a media grid; a review with a
// booking taps through to its detail. Lives on the Overview home's Reviews tab.
//
// Read-only by design — clients author reviews. The web "feature in portfolio"
// toggle on review media is web-only (omitted here).
import SwiftUI
import TovisKit

struct ProReviewsListView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded([ProReviewItem])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var viewingMedia: FullscreenMedia?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 50)
                case let .failed(message):
                    errorState(message)
                case let .loaded(items):
                    if items.isEmpty {
                        Text("No reviews yet.")
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        ForEach(items) { review in
                            reviewCard(review)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 120)   // clear the raised footer
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .mediaFullscreenCover($viewingMedia)
    }

    private func reviewCard(_ review: ProReviewItem) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(review.clientName)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                    Text("• \(review.date)")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                    Spacer()
                }

                stars(review.rating)

                if let headline = review.headline, !headline.isEmpty {
                    Text(headline)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }
                if let body = review.body, !body.isEmpty {
                    Text(body)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textPrimary.opacity(0.85))
                }

                if !review.mediaTiles.isEmpty {
                    mediaGrid(review.mediaTiles)
                }

                if let bookingId = review.bookingId {
                    NavigationLink {
                        ProBookingDetailView(bookingId: bookingId)
                    } label: {
                        Text("View booking")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 14)
                            .overlay(
                                Capsule().stroke(BrandColor.textMuted.opacity(0.30), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func stars(_ rating: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < rating ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(i < rating ? BrandColor.gold : BrandColor.textMuted.opacity(0.4))
            }
        }
        .accessibilityLabel("Rating \(rating) out of 5")
    }

    private func mediaGrid(_ tiles: [ProReviewItem.MediaTile]) -> some View {
        // A paired before is subsumed by its after's slider, so drop it from the grid.
        let beforeIds = Set(tiles.compactMap { $0.before?.id })
        let visible = tiles.filter { !beforeIds.contains($0.id) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(visible) { tile in
                if let before = tile.before, let beforeStr = before.displayUrl,
                   let beforeURL = URL(string: beforeStr), let afterURL = URL(string: tile.src) {
                    // Paired before/after → the comparison slider fills the square cell.
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            GeometryReader { geo in
                                BeforeAfterCompareView(beforeURL: beforeURL, afterURL: afterURL, height: geo.size.height, cornerRadius: 10)
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                        }
                        .clipped()
                } else {
                    Button {
                        // `src` is a signed thumbnail/source URL (poster for video),
                        // so open it as an image — reliable full-size view of the shot.
                        viewingMedia = FullscreenMedia.remote(id: tile.id, urlString: tile.src, isVideo: false)
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BrandColor.bgPrimary)
                            if let url = URL(string: tile.src) {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    ProgressView().tint(BrandColor.accent)
                                }
                            }
                            if tile.isVideo {
                                Text("VIDEO")
                                    .font(BrandFont.mono(8))
                                    .foregroundStyle(BrandColor.textPrimary)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(BrandColor.bgPrimary.opacity(0.72))
                                    .clipShape(Capsule())
                                    .padding(6)
                            }
                        }
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func load() async {
        do {
            let items = try await session.client.proProfile.reviews()
            phase = .loaded(items)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your reviews.")
        }
    }
}
